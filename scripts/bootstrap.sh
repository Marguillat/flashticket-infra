/Users/user/.local/bin/aws sqs create-queue \
--queue-name flashticket-orders-dlq

/Users/user/.local/bin/aws sqs create-queue \
--queue-name flashticket-orders \
--attributes VisibilityTimeout=60,RedrivePolicy="maxReceiveCount 3"

/Users/user/.local/bin/aws dynamodb create-table --table-name orders \
--attribute-definitions AttributeName=orderId,AttributeType=S \
--key-schema AttributeName=orderId,KeyType=HASH \
--billing-mode PAY_PER_REQUEST

/Users/user/.local/bin/aws dynamodb create-table --table-name idempotency \
--attribute-definitions AttributeName=pk,AttributeType=S \
--key-schema AttributeName=pk,KeyType=HASH \
--billing-mode PAY_PER_REQUEST

/Users/user/.local/bin/aws dynamodb update-time-to-live --table-name idempotency \
--time-to-live-specification Enabled=true,AttributeName=ttl

/Users/user/.local/bin/aws kinesis create-stream \
--stream-name flashticket-sales --shard-count 1

cd functions/create-order && npm ci && npm run package && cd ../..

QUEUE_URL=$(aws sqs get-queue-url \
--queue-name flashticket-orders --query QueueUrl --output text)

aws lambda create-function --function-name create-order \
--runtime nodejs20.x --handler index.handler \
--role arn:aws:iam::000000000000:role/lambda-role \
--zip-file fileb://functions/create-order/create-order.zip \
--timeout 10 --environment "Variables={QUEUE_URL=$QUEUE_URL}"

aws lambda create-function-url-config \
--function-name create-order --auth-type NONE

(cd functions/process-order && zip -q -j ../process-order.zip handler.py)

aws lambda create-function --function-name process-order \
--runtime python3.12 --handler handler.handler \
--role arn:aws:iam::000000000000:role/lambda-role \
--zip-file fileb://functions/process-order.zip --timeout 10

QUEUE_ARN=$(aws sqs get-queue-attributes \
--queue-url "$QUEUE_URL" --attribute-names QueueArn \
--query Attributes.QueueArn --output text)

aws lambda create-event-source-mapping \
--function-name process-order --event-source-arn "$QUEUE_ARN" \
--batch-size 10 --function-response-types ReportBatchItemFailures
