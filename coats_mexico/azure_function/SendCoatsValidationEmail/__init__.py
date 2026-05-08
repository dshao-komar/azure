import json
import logging

import azure.functions as func

from coats_function_common import send_validation_email


def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse("Invalid JSON payload.", status_code=400)

    try:
        result = send_validation_email(body)
    except Exception:
        logging.exception("Failed to send Coats Mexico validation email.")
        raise

    return func.HttpResponse(
        json.dumps(result),
        status_code=202,
        mimetype="application/json",
    )
