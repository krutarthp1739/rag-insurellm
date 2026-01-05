import hashlib
import json
import os
import random
import re
import time
from datetime import datetime, timezone
from typing import Dict, List
from urllib.parse import unquote_plus

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

RAW_BUCKET = os.environ["RAW_BUCKET"]
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]
S3_VECTORS_INDEX = os.environ.get("S3_VECTORS_INDEX", "rag-insurellm-dev-kb")
S3_VECTORS_NAMESPACE = os.environ.get("S3_VECTORS_NAMESPACE", "default")
BEDROCK_EMBEDDING_MODEL = os.environ.get("BEDROCK_EMBEDDING_MODEL", "amazon.titan-embed-text-v2:0")

s3_client = boto3.client("s3")
bedrock_client = boto3.client(
    "bedrock-runtime",
    region_name=os.environ.get("AWS_REGION"),
    config=Config(retries={"mode": "adaptive", "max_attempts": 10}),
)


def lambda_handler(event, context):
    records = event.get("Records", [])
    for record in records:
        try:
            process_sqs_record(record)
        except Exception as exc:  # noqa: BLE001
            print(f"Failed to process record {record.get('messageId')}: {exc}")
            raise

    return {"status": "ok", "records": len(records)}


def process_sqs_record(record: Dict):
    body = record.get("body", "{}")
    message = json.loads(body)
    s3_records = message.get("Records", [])
    for s3_record in s3_records:
        process_s3_event(s3_record)


def process_s3_event(s3_record: Dict):
    bucket = s3_record["s3"]["bucket"]["name"]
    key = unquote_plus(s3_record["s3"]["object"]["key"])
    version_id = s3_record["s3"]["object"].get("versionId")
    etag = s3_record["s3"]["object"].get("eTag")

    doc_id = build_doc_id(bucket, key, version_id, etag)
    print(f"Processing {bucket}/{key} as doc_id={doc_id}")

    document_text = fetch_markdown(bucket, key, version_id)
    plain_text = markdown_to_text(document_text)
    chunks = chunk_text(plain_text)

    doc_type = infer_doc_type(key)
    source_uri = f"s3://{bucket}/{key}"
    created_at = datetime.now(timezone.utc).isoformat()

    manifest = {
        "doc_id": doc_id,
        "source": {"bucket": bucket, "key": key, "version_id": version_id},
        "created_at": created_at,
        "chunks": [],
    }

    for idx, chunk in enumerate(chunks):
        chunk_id = f"{doc_id}:{idx}"
        vector_key = vector_object_key(chunk_id)
        if vector_exists(vector_key):
            print(f"Vector already exists for {chunk_id}, skipping embed")
            manifest["chunks"].append(
                {
                    "chunk_id": chunk_id,
                    "doc_type": doc_type,
                    "chunk_text_preview": chunk[:200],
                    "source_s3_uri": source_uri,
                    "length": len(chunk),
                    "created_at": created_at,
                }
            )
            continue

        metadata = {
            "doc_id": doc_id,
            "source_s3_uri": source_uri,
            "chunk_id": chunk_id,
            "doc_type": doc_type,
            "created_at": created_at,
            "chunk_text_preview": chunk[:200],
        }

        embedding = embed_text(chunk)
        store_vector(chunk_id, embedding, metadata)

        manifest["chunks"].append(
            {
                "chunk_id": chunk_id,
                "doc_type": doc_type,
                "chunk_text_preview": chunk[:200],
                "source_s3_uri": source_uri,
                "length": len(chunk),
                "created_at": created_at,
            }
        )

    put_manifest(doc_id, manifest)
    print(f"Completed doc_id={doc_id} with {len(chunks)} chunks")


def build_doc_id(bucket: str, key: str, version_id: str | None, etag: str | None) -> str:
    token = version_id or etag or ""
    base = f"{bucket}:{key}:{token}"
    return hashlib.sha256(base.encode("utf-8")).hexdigest()


def fetch_markdown(bucket: str, key: str, version_id: str | None) -> str:
    try:
        params = {"Bucket": bucket, "Key": key}
        if version_id:
            params["VersionId"] = version_id
        response = s3_client.get_object(**params)
        return response["Body"].read().decode("utf-8")
    except (ClientError, BotoCoreError) as exc:
        raise RuntimeError(f"Failed to fetch {bucket}/{key}: {exc}") from exc


def markdown_to_text(markdown: str) -> str:
    without_code_blocks = re.sub(r"```.*?```", "", markdown, flags=re.DOTALL)
    without_inline_code = re.sub(r"`([^`]*)`", r"\1", without_code_blocks)
    collapsed = re.sub(r"\n{3,}", "\n\n", without_inline_code)
    return collapsed.strip()


def chunk_text(text: str, chunk_size: int = 1200, overlap: int = 200) -> List[str]:
    if not text:
        return []
    chunks: List[str] = []
    start = 0
    text_length = len(text)
    while start < text_length:
        end = min(start + chunk_size, text_length)
        chunks.append(text[start:end])
        if end == text_length:
            break
        start = end - overlap
    return chunks


def embed_text(text: str) -> List[float]:
    payload = json.dumps({"inputText": text})
    max_retries = 8
    base_delay = 0.5

    for attempt in range(max_retries):
        try:
            response = bedrock_client.invoke_model(modelId=BEDROCK_EMBEDDING_MODEL, body=payload)
            body = json.loads(response["body"].read())
            embedding = body.get("embedding") or body.get("vector")
            if not embedding:
                raise RuntimeError("Embedding response missing vector")
            time.sleep(random.uniform(0.05, 0.15))
            return embedding
        except ClientError as exc:
            error_code = exc.response.get("Error", {}).get("Code")
            if error_code == "ThrottlingException" and attempt < max_retries - 1:
                delay = min(8.0, base_delay * (2**attempt)) * random.uniform(0.75, 1.25)
                print(f"Throttle on embed attempt {attempt + 1}/{max_retries}, sleeping {delay:.2f}s")
                time.sleep(delay)
                continue
            raise RuntimeError(f"Failed to embed text with model {BEDROCK_EMBEDDING_MODEL}: {exc}") from exc
        except (BotoCoreError, KeyError, ValueError) as exc:
            raise RuntimeError(f"Failed to embed text with model {BEDROCK_EMBEDDING_MODEL}: {exc}") from exc


def store_vector(chunk_id: str, embedding: List[float], metadata: Dict):
    """
    Placeholder for S3 Vectors upsert. Writes payload to the processed bucket so we
    have an auditable artifact until native S3 Vectors APIs are wired in.
    """
    key = vector_object_key(chunk_id)
    payload = {
        "id": chunk_id,
        "index": S3_VECTORS_INDEX,
        "namespace": S3_VECTORS_NAMESPACE,
        "embedding": embedding,
        "metadata": metadata,
    }
    try:
        s3_client.put_object(
            Bucket=PROCESSED_BUCKET,
            Key=key,
            Body=json.dumps(payload).encode("utf-8"),
            ContentType="application/json",
        )
    except (ClientError, BotoCoreError) as exc:
        raise RuntimeError(f"Failed to store vector {chunk_id}: {exc}") from exc


def vector_object_key(chunk_id: str) -> str:
    return f"vectors/{S3_VECTORS_INDEX}/{S3_VECTORS_NAMESPACE}/{chunk_id}.json"


def vector_exists(key: str) -> bool:
    # Treat missing or access-denied vectors as absent so ingestion can continue.
    try:
        s3_client.head_object(Bucket=PROCESSED_BUCKET, Key=key)
        return True
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code")

        # Not found → doesn't exist
        if error_code in {"404", "NoSuchKey", "NotFound"}:
            return False

        # Access denied → treat as missing (don't fail ingestion)
        if error_code in {"403", "AccessDenied", "Forbidden"}:
            print(f"Warning: access denied checking {key} in processed bucket; treating as missing")
            return False

        raise


def put_manifest(doc_id: str, manifest: Dict):
    key = f"processed/{doc_id}/chunks.json"
    try:
        s3_client.put_object(
            Bucket=PROCESSED_BUCKET,
            Key=key,
            Body=json.dumps(manifest, separators=(",", ":")).encode("utf-8"),
            ContentType="application/json",
        )
    except (ClientError, BotoCoreError) as exc:
        raise RuntimeError(f"Failed to write manifest for {doc_id}: {exc}") from exc


def infer_doc_type(key: str) -> str:
    prefix = key.split("/", 1)[0]
    return prefix if prefix in {"company", "contracts", "employees", "products"} else "unknown"
