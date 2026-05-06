#!/usr/bin/env python3
"""
Extract Coats Mexico shipment workbook rows and pallet comments.

This script intentionally uses only the Python standard library. An .xlsx file is
a zip package of XML parts, which is enough for the current pipeline needs:

- find the "Material Detail" worksheet
- dynamically locate the required header row
- extract the four mapped shipment columns
- read threaded/legacy comments from workbook XML
- split multi-pallet rows when comments provide pallet-level quantities
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import sys
import uuid
import zipfile
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET


SPREADSHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
OFFICE_REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
THREADED_NS = "http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments"
WORKBOOK_REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

REQUIRED_HEADERS = {
    "PALLET": "Bin_ID",
    "MATERIAL": "Item_ID",
    "INVOICED QTY": "Invoiced_Qty",
    "No. PEDIDO CLIENTE": "PO_No",
}

HEADER_ALIASES = {
    "PALLET": "PALLET",
    "MATERIAL": "MATERIAL",
    "INVOICED QTY": "INVOICED QTY",
    "INVOICED_QTY": "INVOICED QTY",
    "NO. PEDIDO CLIENTE": "No. PEDIDO CLIENTE",
    "NO PEDIDO CLIENTE": "No. PEDIDO CLIENTE",
    "PO NUMBER": "No. PEDIDO CLIENTE",
}


@dataclass(frozen=True)
class SheetInfo:
    name: str
    path: str


def normalize_header(value: Any) -> str:
    text = "" if value is None else str(value)
    text = re.sub(r"\s+", " ", text.strip())
    return HEADER_ALIASES.get(text.upper(), text)


def column_letters(cell_ref: str) -> str:
    match = re.match(r"([A-Z]+)", cell_ref.upper())
    if not match:
        raise ValueError(f"Invalid cell reference: {cell_ref}")
    return match.group(1)


def column_number(cell_ref_or_letters: str) -> int:
    letters = column_letters(cell_ref_or_letters)
    value = 0
    for char in letters:
        value = value * 26 + ord(char) - ord("A") + 1
    return value


def row_number(cell_ref: str) -> int:
    match = re.search(r"(\d+)$", cell_ref)
    if not match:
        raise ValueError(f"Invalid cell reference: {cell_ref}")
    return int(match.group(1))


def read_xml(package: zipfile.ZipFile, path: str) -> ET.Element:
    return ET.fromstring(package.read(path))


def resolve_package_path(base_part: str, target: str) -> str:
    if target.startswith("/"):
        return target.lstrip("/")
    return posixpath.normpath(posixpath.join(posixpath.dirname(base_part), target))


def parse_relationships(package: zipfile.ZipFile, rels_path: str) -> dict[str, dict[str, str]]:
    if rels_path not in package.namelist():
        return {}

    root = read_xml(package, rels_path)
    rels: dict[str, dict[str, str]] = {}
    for rel in root.findall(f"{{{REL_NS}}}Relationship"):
        rels[rel.attrib["Id"]] = {
            "type": rel.attrib.get("Type", ""),
            "target": rel.attrib.get("Target", ""),
        }
    return rels


def read_shared_strings(package: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in package.namelist():
        return []

    root = read_xml(package, "xl/sharedStrings.xml")
    strings: list[str] = []
    for item in root.findall(f"{{{SPREADSHEET_NS}}}si"):
        strings.append("".join(node.text or "" for node in item.findall(f".//{{{SPREADSHEET_NS}}}t")))
    return strings


def workbook_sheets(package: zipfile.ZipFile) -> list[SheetInfo]:
    workbook = read_xml(package, "xl/workbook.xml")
    rels = parse_relationships(package, "xl/_rels/workbook.xml.rels")
    sheets: list[SheetInfo] = []

    for sheet in workbook.findall(f"{{{SPREADSHEET_NS}}}sheets/{{{SPREADSHEET_NS}}}sheet"):
        rel_id = sheet.attrib[f"{{{WORKBOOK_REL_NS}}}id"]
        target = rels[rel_id]["target"]
        sheets.append(SheetInfo(name=sheet.attrib["name"], path=resolve_package_path("xl/workbook.xml", target)))

    return sheets


def cell_value(cell: ET.Element, shared_strings: list[str]) -> str | None:
    cell_type = cell.attrib.get("t")

    if cell_type == "inlineStr":
        return "".join(node.text or "" for node in cell.findall(f".//{{{SPREADSHEET_NS}}}t"))

    value_node = cell.find(f"{{{SPREADSHEET_NS}}}v")
    if value_node is None:
        return None

    raw_value = value_node.text
    if raw_value is None:
        return None

    if cell_type == "s":
        return shared_strings[int(raw_value)]

    return raw_value


def worksheet_rows(package: zipfile.ZipFile, sheet_path: str, shared_strings: list[str]) -> list[dict[int, str]]:
    root = read_xml(package, sheet_path)
    rows: list[dict[int, str]] = []

    for row in root.findall(f"{{{SPREADSHEET_NS}}}sheetData/{{{SPREADSHEET_NS}}}row"):
        values: dict[int, str] = {}
        for cell in row.findall(f"{{{SPREADSHEET_NS}}}c"):
            value = cell_value(cell, shared_strings)
            if value is None:
                continue
            values[column_number(cell.attrib["r"])] = value
        rows.append(values)

    return rows


def find_header_mapping(rows: list[dict[int, str]]) -> tuple[int, dict[int, str]]:
    for index, row in enumerate(rows, start=1):
        mapped: dict[int, str] = {}
        for col_index, value in row.items():
            header = normalize_header(value)
            if header in REQUIRED_HEADERS:
                mapped[col_index] = REQUIRED_HEADERS[header]

        if set(mapped.values()) == set(REQUIRED_HEADERS.values()):
            return index, mapped

    required = ", ".join(REQUIRED_HEADERS.keys())
    raise ValueError(f"Could not find a header row containing: {required}")


def sheet_relationships_path(sheet_path: str) -> str:
    directory = posixpath.dirname(sheet_path)
    filename = posixpath.basename(sheet_path)
    return posixpath.join(directory, "_rels", f"{filename}.rels")


def comments_for_sheet(package: zipfile.ZipFile, sheet_path: str) -> dict[str, str]:
    rels = parse_relationships(package, sheet_relationships_path(sheet_path))
    comments: dict[str, str] = {}

    for rel in rels.values():
        target = resolve_package_path(sheet_path, rel["target"])
        rel_type = rel["type"].lower()
        if "threadedcomment" in rel_type and target in package.namelist():
            comments.update(parse_threaded_comments(package, target))

    for rel in rels.values():
        target = resolve_package_path(sheet_path, rel["target"])
        rel_type = rel["type"].lower()
        if rel_type.endswith("/comments") and target in package.namelist():
            for ref, text in parse_legacy_comments(package, target).items():
                comments.setdefault(ref, text)

    return comments


def parse_threaded_comments(package: zipfile.ZipFile, comments_path: str) -> dict[str, str]:
    root = read_xml(package, comments_path)
    comments: dict[str, str] = {}
    for comment in root.findall(f"{{{THREADED_NS}}}threadedComment"):
        ref = comment.attrib.get("ref")
        text_node = comment.find(f"{{{THREADED_NS}}}text")
        if ref and text_node is not None:
            comments[ref.upper()] = text_node.text or ""
    return comments


def parse_legacy_comments(package: zipfile.ZipFile, comments_path: str) -> dict[str, str]:
    root = read_xml(package, comments_path)
    comments: dict[str, str] = {}
    for comment in root.findall(f".//{{{SPREADSHEET_NS}}}comment"):
        ref = comment.attrib.get("ref")
        text = "\n".join(node.text or "" for node in comment.findall(f".//{{{SPREADSHEET_NS}}}t"))
        if ref:
            marker = "Comment:"
            if marker in text:
                text = text.split(marker, 1)[1].strip()
            comments[ref.upper()] = text
    return comments


def parse_decimal(value: Any) -> Decimal | None:
    if value is None:
        return None
    text = str(value).replace(",", "").strip()
    if not text:
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def decimal_to_json(value: Decimal | None) -> str | None:
    if value is None:
        return None
    return format(value.normalize(), "f")


def parse_filename_metadata(file_name: str) -> tuple[date | None, str | None]:
    stem = Path(file_name).stem
    date_match = re.search(r"(\d{1,2})[./_-](\d{1,2})[./_-](\d{2,4})", stem)
    trailer_match = re.search(r"\bTrailer\s+([A-Za-z0-9-]+)\b", stem, flags=re.IGNORECASE)

    shipment_date = None
    if date_match:
        month, day, year = (int(part) for part in date_match.groups())
        if year < 100:
            year += 2000
        shipment_date = date(year, month, day)

    trailer_name = trailer_match.group(1).upper() if trailer_match else None
    return shipment_date, trailer_name


def next_friday_after(value: date) -> date:
    # Monday is 0, Friday is 4. Always return a Friday after the shipment date.
    days_until_friday = (4 - value.weekday()) % 7
    if days_until_friday == 0:
        days_until_friday = 7
    return value + timedelta(days=days_until_friday)


def is_multi_pallet(value: str | None) -> bool:
    if value is None:
        return False
    return "," in value or re.search(r"\b[A-Za-z]+-\d+\s*[-:]\s*\d+\b", value) is not None


def pallet_prefix(value: str | None) -> str:
    if not value:
        return ""
    match = re.search(r"\b([A-Za-z]+)-?\d+\b", value)
    return match.group(1).upper() if match else ""


def parse_comment_pallet_quantities(comment_text: str, source_pallet: str) -> list[dict[str, Any]]:
    prefix = pallet_prefix(source_pallet)
    parsed: list[dict[str, Any]] = []

    for line in comment_text.splitlines():
        pallet_match = re.search(r"\bPallet\s*#?\s*(\d+)\b", line, flags=re.IGNORECASE)
        if not pallet_match:
            continue

        quantity_matches = list(re.finditer(r"(?<!#)\b(\d+(?:\.\d+)?)\b\s*([A-Za-z]+)?", line))
        if len(quantity_matches) < 2:
            continue

        # The first number is the pallet number. The last remaining number is
        # the usable per-pallet quantity in current vendor comments.
        quantity_match = quantity_matches[-1]
        quantity = parse_decimal(quantity_match.group(1))
        if quantity is None:
            continue

        unit = quantity_match.group(2)
        pallet_number = pallet_match.group(1)
        parsed.append(
            {
                "Bin_ID": f"{prefix}-{pallet_number}" if prefix else pallet_number,
                "Parsed_Qty": decimal_to_json(quantity),
                "Parsed_Qty_Unit": unit.lower() if unit else None,
                "Comment_Line": line.strip(),
            }
        )

    return parsed


def extract_workbook(
    workbook_path: Path,
    source_file_name: str,
    source_web_url: str | None,
    pipeline_run_id: str,
    shipment_date_override: str | None,
    trailer_name_override: str | None,
) -> dict[str, Any]:
    shipment_date, trailer_name = parse_filename_metadata(source_file_name)
    validation_issues: list[dict[str, Any]] = []

    if shipment_date_override:
        shipment_date = date.fromisoformat(shipment_date_override)
    if trailer_name_override:
        trailer_name = trailer_name_override.upper()

    estimated_arrival = next_friday_after(shipment_date) if shipment_date else None

    if shipment_date is None:
        validation_issues.append(
            {
                "severity": "BLOCKING",
                "issue_code": "MISSING_SHIPMENT_DATE",
                "message": "Filename does not contain a parseable shipment date.",
            }
        )
    if not trailer_name:
        validation_issues.append(
            {
                "severity": "BLOCKING",
                "issue_code": "MISSING_TRAILER_NAME",
                "message": "Filename does not contain a parseable trailer name.",
            }
        )

    with zipfile.ZipFile(workbook_path) as package:
        shared_strings = read_shared_strings(package)
        sheets = workbook_sheets(package)
        sheet = next((item for item in sheets if item.name == "Material Detail"), None)
        if sheet is None:
            raise ValueError("Required worksheet not found: Material Detail")

        rows = worksheet_rows(package, sheet.path, shared_strings)
        header_row_number, header_mapping = find_header_mapping(rows)
        comment_by_ref = comments_for_sheet(package, sheet.path)
        pallet_column = next(col for col, mapped_name in header_mapping.items() if mapped_name == "Bin_ID")

        raw_lines: list[dict[str, Any]] = []
        pallet_lines: list[dict[str, Any]] = []

        for source_row_number, row in enumerate(rows[header_row_number:], start=header_row_number + 1):
            line: dict[str, Any] = {
                "source_row_number": source_row_number,
                "source_sheet": sheet.name,
            }
            for col_index, mapped_name in header_mapping.items():
                line[mapped_name] = row.get(col_index)

            if not any(line.get(name) for name in REQUIRED_HEADERS.values()):
                continue

            comment_ref = f"{number_to_column_letters(pallet_column)}{source_row_number}"
            raw_comment = comment_by_ref.get(comment_ref)
            line["raw_pallet_comment"] = raw_comment
            raw_lines.append(line)

            required_values = ("Bin_ID", "Item_ID", "Invoiced_Qty", "PO_No")
            for required in required_values:
                if not str(line.get(required) or "").strip():
                    validation_issues.append(row_issue(line, "MISSING_REQUIRED_VALUE", f"Missing required value: {required}"))

            source_qty = parse_decimal(line.get("Invoiced_Qty"))
            if source_qty is None:
                validation_issues.append(row_issue(line, "INVALID_QUANTITY", "INVOICED QTY is not numeric."))

            if is_multi_pallet(line.get("Bin_ID")):
                if not raw_comment:
                    validation_issues.append(
                        row_issue(line, "MISSING_PALLET_COMMENT", "Multi-pallet row does not have a pallet breakdown comment.")
                    )
                    continue

                parsed_pallets = parse_comment_pallet_quantities(raw_comment, str(line.get("Bin_ID") or ""))
                if not parsed_pallets:
                    validation_issues.append(
                        row_issue(line, "UNPARSEABLE_PALLET_COMMENT", "Pallet breakdown comment could not be parsed.")
                    )
                    continue

                parsed_total = sum((parse_decimal(item["Parsed_Qty"]) or Decimal("0")) for item in parsed_pallets)
                quantity_reconciled = source_qty is not None and abs(parsed_total - source_qty) <= Decimal("0.0001")
                if source_qty is not None and not quantity_reconciled:
                    validation_issues.append(
                        row_issue(
                            line,
                            "PALLET_QUANTITY_MISMATCH",
                            f"Parsed pallet quantity total {decimal_to_json(parsed_total)} does not match source quantity {decimal_to_json(source_qty)}.",
                        )
                    )

                for parsed in parsed_pallets:
                    pallet_lines.append(
                        pallet_line_from_raw(line, parsed["Bin_ID"], parsed["Parsed_Qty"], parsed["Parsed_Qty_Unit"], parsed["Comment_Line"], quantity_reconciled)
                    )
            else:
                pallet_lines.append(
                    pallet_line_from_raw(line, line.get("Bin_ID"), decimal_to_json(source_qty), None, None, source_qty is not None)
                )

    return {
        "metadata": {
            "shipment_file_id": str(uuid.uuid4()),
            "source_file_name": source_file_name,
            "source_web_url": source_web_url,
            "shipment_date": shipment_date.isoformat() if shipment_date else None,
            "trailer_name": trailer_name,
            "estimated_arrival_date": estimated_arrival.isoformat() if estimated_arrival else None,
            "pipeline_run_id": pipeline_run_id,
            "loaded_at_utc": datetime.now(timezone.utc).isoformat(),
        },
        "raw_lines": raw_lines,
        "pallet_lines": pallet_lines,
        "validation_issues": validation_issues,
    }


def row_issue(line: dict[str, Any], issue_code: str, message: str) -> dict[str, Any]:
    return {
        "severity": "BLOCKING",
        "issue_code": issue_code,
        "message": message,
        "source_sheet": line.get("source_sheet"),
        "source_row_number": line.get("source_row_number"),
        "Bin_ID": line.get("Bin_ID"),
        "Item_ID": line.get("Item_ID"),
        "PO_No": line.get("PO_No"),
        "raw_pallet_comment": line.get("raw_pallet_comment"),
    }


def pallet_line_from_raw(
    line: dict[str, Any],
    bin_id: Any,
    quantity: str | None,
    quantity_unit: str | None,
    comment_line: str | None,
    quantity_reconciled: bool,
) -> dict[str, Any]:
    return {
        "source_sheet": line.get("source_sheet"),
        "source_row_number": line.get("source_row_number"),
        "Bin_ID": bin_id,
        "Item_ID": line.get("Item_ID"),
        "PO_No": line.get("PO_No"),
        "Invoiced_Qty": quantity,
        "Parsed_Qty_Unit": quantity_unit,
        "raw_pallet_value": line.get("Bin_ID"),
        "raw_pallet_comment": line.get("raw_pallet_comment"),
        "comment_line": comment_line,
        "quantity_reconciled": quantity_reconciled,
    }


def number_to_column_letters(number: int) -> str:
    letters = ""
    while number:
        number, remainder = divmod(number - 1, 26)
        letters = chr(ord("A") + remainder) + letters
    return letters


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract Coats Mexico workbook rows and pallet comments.")
    parser.add_argument("workbook", type=Path, help="Path to the .xlsx workbook.")
    parser.add_argument("--source-file-name", help="Source file name to parse metadata from. Defaults to workbook basename.")
    parser.add_argument("--source-web-url", help="SharePoint web URL for the source file.")
    parser.add_argument("--pipeline-run-id", default="local", help="ADF pipeline run id or local run marker.")
    parser.add_argument("--shipment-date", help="Override shipment date as YYYY-MM-DD.")
    parser.add_argument("--trailer-name", help="Override trailer name, for sample files without filename metadata.")
    parser.add_argument("--output", type=Path, help="Optional JSON output path. Defaults to stdout.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source_file_name = args.source_file_name or args.workbook.name
    payload = extract_workbook(
        workbook_path=args.workbook,
        source_file_name=source_file_name,
        source_web_url=args.source_web_url,
        pipeline_run_id=args.pipeline_run_id,
        shipment_date_override=args.shipment_date,
        trailer_name_override=args.trailer_name,
    )

    output = json.dumps(payload, indent=2, ensure_ascii=False)
    if args.output:
        args.output.write_text(output + "\n", encoding="utf-8")
    else:
        print(output)

    blocking_issues = [issue for issue in payload["validation_issues"] if issue.get("severity") == "BLOCKING"]
    return 2 if blocking_issues else 0


if __name__ == "__main__":
    sys.exit(main())
