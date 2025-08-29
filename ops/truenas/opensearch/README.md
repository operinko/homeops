# OpenSearch on TrueNAS (single node)

This folder contains a docker-compose.yaml you can paste into TrueNAS SCALE (Apps → Custom App → Install via YAML) to run a single-node OpenSearch instance on a ZFS dataset.

- Data path on TrueNAS host: set volumes:/mnt/…/OpenSearch → /bitnami/opensearch
- Port: host 9200 → container 9200
- Security: disabled initially to simplify bootstrap; we can enable and secure with TLS/Basic Auth once snapshots and pipelines are verified.

## Install
1. Apps → Custom App → Install via YAML
2. Paste `docker-compose.yaml` (modify the /mnt path to your dataset)
3. Save → Wait until container is healthy
4. Hit http://<truenas-ip>:9200/ to verify

## MinIO snapshots
We will snapshot indices to MinIO at `https://minio.vaderrp.com:9000`.

- Create an S3 bucket (suggested name): `opensearch-snapshots`
- Create an S3 user with access key/secret limited to that bucket
- Apply this bucket policy (replace <bucket> and <user-arn>):

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBucketListing",
      "Effect": "Allow",
      "Principal": {"AWS": ["<user-arn>"]},
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::<bucket>"]
    },
    {
      "Sid": "AllowObjectOps",
      "Effect": "Allow",
      "Principal": {"AWS": ["<user-arn>"]},
      "Action": [
        "s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload"
      ],
      "Resource": ["arn:aws:s3:::<bucket>/*"]
    }
  ]
}
```

Note: In MinIO, the user ARN often takes the form `arn:aws:iam:::user/<username>`. If Policies tab is easier, attach an equivalent inline policy to the user covering only this bucket.

### Register S3 repository (from TrueNAS shell or any host that can reach port 30920)
1. Ensure repository-s3 plugin is present (it is included in the upstream image, but if missing you can install with the built-in tool):

```
# Exec into the pod (TrueNAS UI or kubectl if available)
/opensearch/bin/opensearch-plugin list
# if repository-s3 is missing, inside the container run:
/opensearch/bin/opensearch-plugin install repository-s3
```

2. Create the repository (replace ACCESS_KEY/SECRET_KEY and BUCKET):

```
curl -XPUT "http://<truenas-ip>:30920/_snapshot/minio" -H 'Content-Type: application/json' -d '{
  "type": "s3",
  "settings": {
    "endpoint": "minio.vaderrp.com:9000",
    "protocol": "https",
    "bucket": "opensearch-snapshots",
    "path_style_access": true,
    "access_key": "<ACCESS_KEY>",
    "secret_key": "<SECRET_KEY>"
  }
}'
```

3. Test snapshot:

```
curl -XPUT "http://<truenas-ip>:30920/_snapshot/minio/smoke-$(date +%s)?wait_for_completion=true"
```

## 7‑day hot ISM policy
Rollover at 2Gi or 1 day; keep 7 days hot; delete afterward. Apply to `logs-*`.

```
cat > ism-logs-7d.json <<'JSON'
{
  "policy": {
    "description": "7d hot, rollover 2Gi/1d, then delete",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [
          {"rollover": {"min_size": "2gb", "min_index_age": "1d"}}
        ],
        "transitions": [
          {"state_name": "delete", "conditions": {"min_index_age": "7d"}}
        ]
      },
      {"name": "delete", "actions": [{"delete": {}}], "transitions": []}
    ]
  }
}
JSON

curl -XPUT "http://<truenas-ip>:30920/_plugins/_ism/policies/logs-7d" -H 'Content-Type: application/json' --data-binary @ism-logs-7d.json

# Template for logs-*
cat > template-logs.json <<'JSON'
{
  "index_patterns": ["logs-*"],
  "template": {
    "settings": {
      "index": {
        "opendistro\.index_state_management\.policy_id": "logs-7d",
        "number_of_shards": "1",
        "number_of_replicas": "0"
      }
    }
  }
}
JSON

curl -XPUT "http://<truenas-ip>:30920/_index_template/logs-template" -H 'Content-Type: application/json' --data-binary @template-logs.json
```

## Next steps (Kubernetes side)
- I’ll wire up Fluent Bit:
  - DaemonSet for k8s logs → http://opensearch.truenas:30920
  - Syslog gateway with LB at 192.168.7.8 → same OpenSearch
- OpenSearch Dashboards in k8s at https://security.vaderrp.com (Authentik)

