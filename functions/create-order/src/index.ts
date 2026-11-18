// create-order : reçoit la commande (Function URL), valide, publie dans SQS, répond 202.
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { randomUUID } from "node:crypto";
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from "aws-lambda";

// Astuce : le client est créé HORS du handler, il est réutilisé entre les invocations.
// L'endpoint LocalStack est lu automatiquement dans AWS_ENDPOINT_URL quand il est défini.
const sqs = new SQSClient({});
const QUEUE_URL = process.env.QUEUE_URL!;

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function reply(statusCode: number, body: unknown, correlationId?: string): APIGatewayProxyResultV2 {
  return {
    statusCode,
    headers: { "content-type": "application/json", ...(correlationId ? { "x-correlation-id": correlationId } : {}) },
    body: JSON.stringify(body),
  };
}

function header(headers: APIGatewayProxyEventV2["headers"], name: string): string | undefined {
  const expected = name.toLowerCase();
  const value = Object.entries(headers ?? {}).find(([key]) => key.toLowerCase() === expected)?.[1];
  return value?.trim() || undefined;
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  // L'identifiant de corrélation suit la commande de bout en bout (journaux).
  const correlationId = header(event.headers, "x-correlation-id") ?? randomUUID();

  const idempotencyKey = header(event.headers, "idempotency-key");
  if (!idempotencyKey) {
    return reply(400, { error: "missing_idempotency_key" }, correlationId);
  }

  const errors: string[] = [];
  let body: unknown;
  try {
    const rawBody = event.body
      ? event.isBase64Encoded
        ? Buffer.from(event.body, "base64").toString("utf8")
        : event.body
      : "";
    body = JSON.parse(rawBody);
  } catch {
    return reply(400, { error: "invalid_body", errors: ["body must be valid JSON"] }, correlationId);
  }

  const input = typeof body === "object" && body !== null ? body as Record<string, unknown> : {};
  const eventId = input.eventId;
  const seats = input.seats;
  const email = input.email;
  const validEventId = typeof eventId === "string" && eventId.trim() ? eventId : undefined;
  const validSeats = typeof seats === "number" && Number.isInteger(seats) && seats >= 1 && seats <= 6
    ? seats
    : undefined;
  const validEmail = typeof email === "string" && EMAIL_RE.test(email) ? email : undefined;

  if (validEventId === undefined) {
    errors.push("eventId must be a non-empty string");
  }
  if (validSeats === undefined) {
    errors.push("seats must be an integer between 1 and 6");
  }
  if (validEmail === undefined) {
    errors.push("email must be a valid email address");
  }
  if (errors.length > 0) {
    return reply(400, { error: "validation_error", errors }, correlationId);
  }

  const orderId = randomUUID();
  const message = {
    orderId,
    correlationId,
    idempotencyKey,
    eventId: validEventId,
    seats: validSeats,
    email: validEmail,
    createdAt: new Date().toISOString(),
  };
  await sqs.send(new SendMessageCommand({
    QueueUrl: QUEUE_URL,
    MessageBody: JSON.stringify(message),
  }));

  console.log(JSON.stringify({ level: "info", msg: "commande publiée", correlationId, orderId }));

  return reply(202, { orderId, correlationId }, correlationId);
};
