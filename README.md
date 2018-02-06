# kube-backup

Dumps the whole cluster as YAML and packs it together to ship of to S3 storage

The RBAC permissions included gives the backup pod CLUSTER ADMIN and should be revised for production cases