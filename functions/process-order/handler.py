"""process-order : consomme un lot de messages SQS, de façon idempotente.

Variables d'environnement : TABLE_ORDERS, TABLE_IDEMPOTENCY, STREAM_NAME.
L'endpoint LocalStack est lu automatiquement dans AWS_ENDPOINT_URL quand il est défini.
"""
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

# Clients créés hors du handler : réutilisés entre invocations.
dynamodb = boto3.client("dynamodb")
kinesis = boto3.client("kinesis")

TABLE_ORDERS = os.environ.get("TABLE_ORDERS", "orders")
TABLE_IDEMPOTENCY = os.environ.get("TABLE_IDEMPOTENCY", "idempotency")
STREAM_NAME = os.environ.get("STREAM_NAME", "flashticket-sales")
TTL_SECONDS = 24 * 3600


def log(level, msg, **fields):
    print(json.dumps({"level": level, "msg": msg, **fields}))


def process_message(order):
    """Traite UNE commande. Lève une exception pour la signaler en échec."""
    idempotency_key = order["idempotencyKey"]
    order_id = order["orderId"]
    now = int(time.time())

    try:
        dynamodb.put_item(
            TableName=TABLE_IDEMPOTENCY,
            Item={
                "pk": {"S": idempotency_key},
                "status": {"S": "IN_PROGRESS"},
                "orderId": {"S": order_id},
                "ttl": {"N": str(now + TTL_SECONDS)},
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            log("info", "commande déjà traitée", orderId=order_id, idempotencyKey=idempotency_key)
            return
        raise

    dynamodb.put_item(
        TableName=TABLE_ORDERS,
        Item={
            "orderId": {"S": order_id},
            "correlationId": {"S": order["correlationId"]},
            "idempotencyKey": {"S": idempotency_key},
            "eventId": {"S": order["eventId"]},
            "seats": {"N": str(order["seats"])},
            "email": {"S": order["email"]},
            "createdAt": {"S": order["createdAt"]},
        },
    )

    event = {
        "type": "OrderConfirmed",
        "orderId": order_id,
        "correlationId": order["correlationId"],
        "eventId": order["eventId"],
        "seats": order["seats"],
        "email": order["email"],
        "createdAt": order["createdAt"],
    }
    kinesis.put_record(
        StreamName=STREAM_NAME,
        Data=json.dumps(event).encode("utf-8"),
        PartitionKey=order_id,
    )

    dynamodb.update_item(
        TableName=TABLE_IDEMPOTENCY,
        Key={"pk": {"S": idempotency_key}},
        UpdateExpression="SET #status = :done",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={":done": {"S": "DONE"}},
    )
    log("info", "commande confirmée", orderId=order_id, correlationId=order["correlationId"])


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            order = json.loads(record["body"])
            process_message(order)
        except Exception as exc:  # noqa: BLE001 : on renvoie l'élément en échec, pas tout le lot
            log("error", "message en échec", messageId=record["messageId"], error=str(exc))
            failures.append({"itemIdentifier": record["messageId"]})
    # ReportBatchItemFailures : seuls ces messages seront rejoués.
    return {"batchItemFailures": failures}
